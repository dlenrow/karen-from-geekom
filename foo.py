import requests
from bs4 import BeautifulSoup
import pandas as pd

def get_patents_for_assignee(assignee_name):
    # Prepare the URL for Google Patents search
    search_url = f'https://patents.google.com/?assignee={assignee_name.replace(" ", "+")}&num=100'
    
    # Send a GET request to the URL
    response = requests.get(search_url)
    
    # Check if the request was successful
    if response.status_code != 200:
        print(f"Error fetching the data: {response.status_code}")
        return None
    
    # Parse the HTML content with BeautifulSoup
    soup = BeautifulSoup(response.text, 'html.parser')
    
    # Find all patent result entries
    results = soup.find_all('tr', {'itemprop': 'tr'})

    # List to store the extracted data
    patents = []

    # Loop through each result entry and extract data
    for result in results:
        patent_number = result.find('td', {'itemprop': 'publicationNumber'}).text.strip()
        patent_title = result.find('span', {'itemprop': 'title'}).text.strip()
        patent_url = f"https://patents.google.com/patent/{patent_number}"
        
        # Append to the patents list
        patents.append({
            'Patent Number': patent_number,
            'Title': patent_title,
            'URL': patent_url
        })

    return patents

def save_to_csv(patents, filename="illumio_patents.csv"):
    # Convert the list of patents to a DataFrame
    df = pd.DataFrame(patents)
    
    # Save the DataFrame to a CSV file
    df.to_csv(filename, index=False)
    print(f"Data saved to {filename}")

if __name__ == "__main__":
    # Define the assignee name
    assignee_name = "Illumio"
    
    # Fetch patents for the assignee
    patents = get_patents_for_assignee(assignee_name)
    
    if patents:
        # Save the results to a CSV file
        save_to_csv(patents)

